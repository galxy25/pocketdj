state: implemented

# P2-REL-1: Release docs and build

Docs/build package: no Kotlin changed, so the JVM test count did not move by design (7927 tests, 0 failures at the tip).

- [x] Ledger reconciled: 11 stale parity-1 "Planned" rows (incl. MIX-18, `a8c08625`) set to Merged with merge SHAs; new "Parity 2 status ledger" (all 87 packages) in docs/ARCHITECTURE-ANDROID.md; follow-on note in docs/architecture/android-parity.md. Rows still PARTIAL left PARTIAL (merged with deliberately deferred pieces). (The integrator still updates the ledger for this package itself.)
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
