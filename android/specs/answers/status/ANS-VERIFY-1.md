state: reviewed

# ANS-VERIFY-1 "No PARTIAL anywhere" sweep

- [x] Every PARTIAL/Planned ledger row classified (EMU / DEV / DEFAULT / CODE / out of scope) in android/specs/answers/PROGRESS.md
- [x] DEVICE-CHECKLIST.md: one checkbox per device-only item with steps (Q9, Q13, Q36, Q41, Q84, Q86, Q6, Q15 BT, plus AM, SAF, location, Auto, sync)
- [ ] HANDOFF (state is not 'done' until the integrator runs these): emulator steps NOT run: this agent may not use the shared emulator. The PROGRESS.md table marks rows tagged EMU for the integrator to drive (shots to pocketdj-answers/_shots/verify/).
- [x] docs/ARCHITECTURE-ANDROID.md untouched (integrator updates the ledger).

## Deviations
- No emulator pass, so rows are not flipped to DONE; honest dispositions instead. Rows MIX-12/17/18, STU-5/8/9/15/16, GM-8/10, BRW-11/15, COL-8 remain Planned: they are not in the answers program.
- PROGRESS.md created fresh under answers/ (wave sections previously lived in parity/PROGRESS.md).

## Questions for Levi
- None new (existing OPEN Q103-Q124 stand). Q15 (BT resume) is answered by PB-4 (held restore); verify via the Android Auto reboot resume card in DEVICE-CHECKLIST.md.

## Summary
Sweep and device checklist written; full JVM suite 5681 tests, 0 failures; assembleDebug green. No new tests required (count unchanged from wave 11: 5681).

## Emulator work list (integrator must run; one step per EMU row, shot to pocketdj-answers/_shots/verify/<ROW>.png)
SURF-2 tiered start + prune log; SURF-6 relaunch persistence; SVC-1 Still-ripping flow; SVC-4 burned-first + Stop; SVC-7/9/10 two-emulator link/restore; SVC-11/PB-5 History glyph + live row; PB-10 rip->rip gap; COL-6 drag to Collections; COL-7/12 add flows; COL-10 favorites; COL-18/20 History > Pockets; BRW-7 timeline; BRW-10/12/13 For You; MIX-5/11/13/14/15/16 Mix pass; STU-3/4/6/7/11/12/14 Producer flows; GM-4/7 games.

## Review
- MAJOR stale CODE tags (SURF-2, SVC-11/PB-5, COL-7/10/12): fixed. Re-checked against HEAD; rows now name closing files. Test AnswersProgressLedgerTest guards it.
- MAJOR "implemented" without emulator pass: fixed. State was reviewed/handoff; explicit EMU work list added above.
- MINOR BRW-7 missing: fixed (row added with DEFAULT tags).
- MINOR SVC-8 untagged: fixed (DONE except Q119 publish).
- NIT Q15: fixed (PB-4).

fixes applied. Suite: 5684 tests, 0 failures (was 5681, +3); assembleDebug green.
