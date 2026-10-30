state: implemented

# ANS-VERIFY-1 "No PARTIAL anywhere" sweep

- [x] Every PARTIAL/Planned ledger row classified (EMU / DEV / DEFAULT / CODE / out of scope) in android/specs/answers/PROGRESS.md
- [x] DEVICE-CHECKLIST.md: one checkbox per device-only item with steps (Q9, Q13, Q36, Q41, Q84, Q86, Q6, Q15 BT, plus AM, SAF, location, Auto, sync)
- [ ] Emulator steps NOT run: this agent may not use the shared emulator. The PROGRESS.md table marks rows tagged EMU for the integrator to drive (shots to pocketdj-answers/_shots/verify/).
- [x] docs/ARCHITECTURE-ANDROID.md untouched (integrator updates the ledger).

## Deviations
- No emulator pass, so rows are not flipped to DONE; honest dispositions instead. Rows MIX-12/17/18, STU-5/8/9/15/16, GM-8/10, BRW-11/15, COL-8 remain Planned: they are not in the answers program.
- PROGRESS.md created fresh under answers/ (wave sections previously lived in parity/PROGRESS.md).

## Questions for Levi
- None new (existing OPEN Q103-Q124 stand). Q15 (BT resume) is covered by PB-6 resumption; verify in the device checklist.

## Summary
Sweep and device checklist written; full JVM suite 5681 tests, 0 failures; assembleDebug green. No new tests required (count unchanged from wave 11: 5681).
