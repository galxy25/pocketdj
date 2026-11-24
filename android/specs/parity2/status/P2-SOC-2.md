state: merged

# P2-SOC-2 — Profile sync go-live code (dormant)

- [x] CameraX + zxing QR scanner (QrScanner.kt), CAMERA requested on demand with prominent in-flow explanation; "Scan code" button in Link a device
- [x] `pocketdj://link/<code>` and `pocketdj://link?code=` -> DeepLink.LinkDevice (checksum-validated); dispatcher parks it in LinkDeviceRequests and opens Settings; no-op message when profileSyncBase absent
- [x] Account deletion already calls s3Database.deleteProfile() when sync configured (ServicesGraph.deleteCloudProfile) — verified, no change
- [x] LinkCodeParseTest (8 tests); full suite 7845 tests, 0 failures; assembleDebug + assembleRelease green

## Deviations / touched outside owned files
- zxing decodes camera frames (no ML Kit): zxing-core already a dependency. CameraX 1.4.1 added (libs.versions.toml, build.gradle.kts).
- Manifest: CAMERA permission + optional camera uses-feature.
- Added ShellRoute.Settings (ShellRoute.kt, ShellNavigation.kt exhaustive whens), DeepLinkParser/Dispatcher branches, new data/sync/LinkDeviceRequests.kt.
- Tests landed in LinkCodeParseTest (manifest camera assertion included there rather than ManifestPermissionsTest).

## Questions for Levi
- Publish the endpoints doc with profileSyncBase? Default: no, code ships dormant.

## Review
fixes applied
- MINOR QrScanner camera bound after dispose -> fixed (disposed flag checked in listener; clearAnalyzer before executor shutdown)
- MINOR shared MultiFormatReader -> fixed (decode guarded by synchronized(reader))
- NIT luminance rows -> fixed (uses frame height, pads buffer if short)
- NIT parked deep-link code lifetime -> not changed (optional; harmless)
- NIT deleteProfile wiring test -> not added (optional; wiring verified at ServicesGraph)
- No new tests: fixes are camera/threading lifecycle, not unit-testable (no MAJOR). Suite 7845, 0 failures.
