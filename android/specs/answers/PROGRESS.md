# Answers program - progress

## Wave 12 (ANS-VERIFY-1): "no PARTIAL anywhere" sweep

This sweep was done WITHOUT the emulator (the integrator owns the shared emulator). Every PARTIAL/Planned row of docs/ARCHITECTURE-ANDROID.md was classified from its ledger text and the per-package status files. Rows needing an emulator pass are listed for the integrator; device-only items are in DEVICE-CHECKLIST.md. The integrator updates the ledger itself.

Legend: **DEV** = remaining gap is device-only (DEVICE-CHECKLIST.md). **EMU** = integrator must run the emulator step (shots to pocketdj-answers/_shots/verify/). **DEFAULT** = kept by a Levi "default" (QUESTIONS.md). **CODE** = a code gap not covered by any ANS package; kept as a documented default.

| Row | Disposition |
|---|---|
| SURF-2 | EMU (tiered start, storage-prune log); CODE: storage prune measure-only, jukebox onStart bootstrap deferred (DEFAULT) |
| SURF-3 | DEV (real AM sign-in); link probe now live via SVC-9 |
| SURF-4 | DEV (App Links verification); seams importCollection/mwf done by COL-14/GM-10 packages |
| SURF-5 | DEV (Assistant voice); MixFacade implemented by MIX-16 |
| SURF-6 | EMU (relaunch persistence; JVM DataStore test covers) |
| SURF-7 | DEV (widget render, cold start) |
| SURF-8 / SURF-9 | DEV (head unit / DHU); EMU with DHU if available |
| SURF-10 | DEV (AM catalog search stage) |
| SVC-1 | EMU (Still ripping flow, mid-queue URL refresh); DEV presigned private bucket |
| SVC-4 | EMU (burned-first resolver, Rip/Burn bar Stop); CODE: Stemify from the bar (SVC-11 covers action) |
| SVC-7 / SVC-9 / SVC-10 | EMU two-emulator link/restore (Q119-Q121); DEV relink; CODE: QR camera scan deferred (code entry + QR display shipped), sources/appleMusicPrivateSync re-emit only (DEFAULT) |
| SVC-8 | Lambda deployed to green by ANS-SYNC-1; endpoints doc publish pending (Q119) |
| SVC-11 / PB-5 | EMU (History glyph + live row); CODE: noteSkip per-song count unwired until a PlayCountService port exists (DEFAULT) |
| SVC-14 | DEV (SD card); DEFAULT staged-copy doubling |
| PB-10 | EMU (rip->rip gap, mid-track reorder) |
| COL-6 | EMU (drag onto Collections row) |
| COL-7 / COL-12 | EMU; CODE: owner-gate seam only (no owner identity), no catalogAdd producer (DEFAULT) |
| COL-9 / COL-11 | DEV (real AM + MUT); CODE: reconcile removals partly landed by GAP-2; Q114 |
| COL-10 | EMU (favorites drive); CODE: backup/profile-sync registration and remapSongIds caller |
| COL-14 | CODE: Q115 edits overlay (DEFAULT: stored only) |
| COL-18 / COL-20 | EMU (History > Pockets); DEV (dwell); CODE: Open Now Playing after Play (Q91 default) |
| BRW-10 / BRW-12 / BRW-13 | EMU (For You flows); CODE: New/release feed BRW-14, RecSuggestionFilter, similarSongs, enqueueAudioAnalysis (DEFAULT deferred) |
| BRW-16 / BRW-17 | DEV (AM write; Q84 AAR missing); CODE: pre-release album refresh, retry UI |
| MIX-5 / MIX-11 / MIX-13 / MIX-14 / MIX-15 / MIX-16 | EMU (Mix pass: sliders, crate menus, sessions replay, History tagging); DEV audio quality/BT (checklist); CODE: CSV export in sessions (GAP-7 covers tracklist CSV), tablet layout, launch-time restore (DEFAULT) |
| MIX-12 / MIX-17 / MIX-18 | Planned: not in the answers program; remain Planned (parity waves) |
| STU-3 / STU-4 / STU-6 / STU-7 / STU-14 / STU-12 / STU-11 | EMU (Producer sub-tab flows); DEV (mic, seam clicks, real stems); CODE: stem carve in STU-3 delivered by GAP-6, Q118 preview audition (DEFAULT) |
| STU-5 / STU-8 / STU-9 / STU-15 / STU-16 | Planned: outside answers scope, see parity roadmap |
| STU-10 | CODE: take-score overdub (DEFAULT deferred); DEV MIDI hardware |
| GM-4 / GM-7 | EMU (Gem Collector, In the Pocket flows); DEV cloud mode |
| GM-8 / GM-10 | Planned: outside answers scope; GM-3 deep links done |
| BRW-11 / BRW-15, COL-8 | Planned: outside answers scope |

Full JVM suite count at this tip is recorded in status/ANS-VERIFY-1.md.
