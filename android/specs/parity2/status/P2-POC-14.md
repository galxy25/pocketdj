state: in-progress

# P2-POC-14 — pocket-wheel-parity.json goldens

- [x] Swift opt-in dump test (apple/Tests/Unit/PocketWheelParityDumpTests.swift)
- [ ] Generate apple/Tests/Fixtures/pocket-wheel-parity.json via xcodebuild + one-at-a-time.sh
- [x] Android golden test written (PocketWheelParityGoldenTest.kt)
- [ ] Copy golden to android/app/src/test/resources/fixtures/, run JVM tests, count

Notes: apple/PocketDJ.xcodeproj/project.pbxproj regenerated with xcodegen to register the new test file (outside owned files).
