state: merged

# STU-9 — Score: quantizer, layout, editor (Enter/Select/Move/Edit, undo/cancel), live staff, PDF + MIDI + audio export

## Checklist
- [x] ScoreQuantizer + NoteDuration/ClefPlan/ScoreDocument, ScorePlayhead (studio/score)
- [x] ScoreLayout (glyph vocabulary, paginate/systems, hit-testing, playhead, played marks)
- [x] ScoreRenderer + ScorePdf (android.graphics.pdf.PdfDocument, vector) in ScorePdf.kt
- [x] SmfWriter (type-0, PPQ 480, RAW events), SmfParser (pure Kotlin, formats 0/1/2, tempo map, running status, ch10 dropped), MidiImport
- [x] ScoreEditor (pure ScoreEdits + Compose canvas, 4 modes, value-based Set selection, multi-step undo, bar add/remove, cursor), CancelAction
- [x] ScoreScreen (Replay + cursor/tap-to-seek, Edit/Done/Cancel, PDF/MIDI/Audio share via FileProvider, overdub staff sections)
- [x] LiveStaff (live staff + Save as take), wired into InstrumentsScreen; Takes menu "Open score"
- [x] Full suite green at committed tip: 3759 JVM tests, 0 failures (+78 new: ScoreQuantizerTest 24, ScoreLayoutTest 23, SmfRoundTripTest 13, ScoreEditsTest 18); assembleDebug green

## Deviations / notes
- Save-as-take / MIDI import render the REAL audio through the instrument's bank at save time (TakeFiler.file) instead of iOS's silent placeholder + background render; both need the pack, so with no pack they fail with the "Download the X pack" message.
- MIDI import has the library function (`MidiImport.importTake`) but NO file-picker button yet: the Instruments tab layout is STU-8's; add an "Import MIDI" row there (ActivityResultContracts.OpenDocument) in a follow-up.
- Live staff is single-staff (overdub staffs are not ported; owned by a later package). Saved takes with `extraStaffs` DO render/edit their extra staffs in ScoreScreen.
- Touched outside owned files (minimal, additive): `studio/engine/InstrumentEngine.kt` (+`setLiveEvents`), `TakesScreen.kt` (`onOpenScore` param + "Open score" menu item), `InstrumentsScreen.kt` (score route + LiveStaff).
- Cancel restores each staff's pre-edit stream; a derive-from-raw staff goes back to `editedEvents = nil` via revert (never pinned).
- Edit > accidental follows iOS exactly (re-spells on the staff line the note currently sits on), so D#4 -> Flat = Db4.
- docs/ARCHITECTURE-ANDROID.md NOT edited (integrator).

## Device-only / unverified
- PDF/Canvas rendering and the clef/rest vector paths are not JVM-testable (android.graphics); emulator steps NOT run (emulator is the integrator's).

## Questions for Levi
- None blocking.

## Review
fixes applied
- MAJOR replay clock/resume read engine global park -> fixed: `ScoreCursor` (clock only reads engine while THIS take replays; resume uses screen `parked`, set on Stop/Edit); natural end clears parked. Tests: ScoreCursorTest.
- MAJOR no BackHandler on score route -> fixed (InstrumentsScreen BackHandler pops to Takes).
- MAJOR MIDI import had no UI -> fixed: "Import MIDI" button in Takes header (OpenDocument, IO read, MidiImport.importTake, surfaces MidiImportException.message).
- MINOR pointerInput stale scale/page -> fixed (added to keys).
- MINOR LiveStaff save wipes notes during render -> fixed: live stream cleared at tap, restored on failure if still empty. Placeholder-save with no pack: rejected (needs silent placeholder + deferred render infra in TakeFiler/reconcile; pack-missing message kept).
- MINOR editing/preEdit/parked lost on recreation -> fixed: `editing`/`parked` rememberSaveable, pre-edit snapshot in process-scoped `ScorePreEditCache` (edit mode drops if snapshot gone). Per-take persisted score cursor (iOS setScoreCursorMs): not ported (rejected; in-session cursor only).
- MINOR seek clamp / stacked loads -> fixed: clamp to 0..end, seeks ignored while preparing.
- MINOR status/ledger/tests -> store-level Cancel test added (editedEvents == null after Revert). Ledger row left to integrator (as per package convention); emulator/PDF-viewer steps still unrun (integrator).
- NIT Paint churn -> fixed: cached stroke/fill paints.
Tests: 3759 -> 3764, 0 failures; assembleDebug green.
