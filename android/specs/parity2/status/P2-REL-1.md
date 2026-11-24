state: reviewed

# P2-REL-1: Release docs and build

Docs/build package: no Kotlin changed, so the JVM test count did not move by design (7927 tests, 0 failures at the tip).

- [x] Ledger reconciled: 11 stale parity-1 "Planned" rows (incl. MIX-18, `a8c08625`) set to Merged with merge SHAs; new "Parity 2 status ledger" (all 86 packages) in docs/ARCHITECTURE-ANDROID.md; follow-on note in docs/architecture/android-parity.md. Rows still PARTIAL left PARTIAL (merged with deliberately deferred pieces). (The integrator still updates the ledger for this package itself.)
- [x] android/specs/parity2/DEVICE-CHECKLIST.md: 36 rows (every device_only + device-only follow-ups Q13/Q14/Q15/Q33/Q40, POC-12, DJ-8) with Result/Notes columns.
- [x] android/specs/parity2/RELEASE.md: What's new (434 chars), Data safety deltas, permission + FGS declarations, App Actions upload, privacy-policy motion text, build steps.
- [x] Verified: `:app:testDebugUnitTest :app:assembleDebug :app:assembleRelease` green.

## Deviations
- docs/legal/PRIVACY.md still says Android does not read physical activity (lines ~66, 141, 207). It is a lawyer-reviewed legal doc outside owned files, so the replacement text is in RELEASE.md section 4 and must be applied before the release ships.
- The signed AAB was not built here: release-aab.sh needs the signing keys and should run from main after the wave merge (`android/scripts/release-aab.sh`); the script itself was not modified. assembleRelease was run and is green.
- First gradle run hit a Kotlin daemon OOM (GC overhead) while other builds ran; passing `-Pkotlin.daemon.jvmargs=-Xmx6g` fixed it. Not a code issue.

## Questions for Levi
- P2Q8 default stands: Internal testing, device checklist, then production at 20 % staged rollout.
- PRIVACY.md motion text (RELEASE.md section 4): OK to apply and have the lawyer re-check before submission?
- Release-relevant open items: DJ Mode on in release (P2Q22); /remote broker undeployed (P2Q36).

## Review
- MAJOR AAB/release gate not run -> fixed (docs): scope can't be met in this worktree (needs signing keys and main after merge, and no emulator). Added RELEASE.md section 0 hard blockers requiring release-aab.sh + emulator release smoke to be recorded before release-ready. Not marked release-ready here.
- MAJOR Data safety motion claims -> fixed: verified in code that Delete history and Delete account wipe the on-device motion timeline (wheelClearLocal) and that the label uploads only while motion opt-in is active (svc.motionOptedIn); could not verify server-side deletion of uploaded pockets (not in cloudDocKeys), so wording softened and made a blocker; PRIVACY.md update is now a hard pre-submission blocker.
- MINOR 87 vs 86 / emulator claim -> fixed: count corrected to 86 here and in the ledger intro (grep confirms intro was the only place); blanket emulator claim qualified; REL-1 row now says Merged.
- MINOR What's new vs flags -> fixed: copy tied to P2Q22 (DJ_MODE getter is true, so DJ Mode ships; delete sentence if held) and P2Q36 (copy makes no internet-Remote or link-a-device claims).

Fixes applied. Docs only, no Kotlin changed, so the test count is unchanged (7927); no gradle run needed.
