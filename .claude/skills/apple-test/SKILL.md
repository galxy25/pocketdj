---
name: apple-test
description: Run the native PocketDJ apps' unit + UI tests on iPhone, iPad, and Mac. Use when asked to "test the apple app", "run the swift tests", "run xcuitests", "verify the native app", or to confirm a native feature works across devices. Covers xcodebuild test on simulators + macOS, the fixture/launch-arg seams, the ad-hoc macOS signing workaround, and the test layout.
---

# Test the native PocketDJ apps (Apple platforms)

Two layers, both under `apple/Tests/`:

1. **Unit tests** (`Tests/Unit/`) — pure logic, no UI: filter/sort engines,
   genre categorizer, Camelot, formatting, settings persistence, multi-source
   merge. The data layer is behind the `CatalogLoading` protocol so these run
   offline against an in-memory fixture (`TestData`).
2. **XCUITests** (`Tests/UI/`) — drive the real app on each device. They launch
   against a **bundled fixture catalog** so they're offline + deterministic.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apple
xcodegen generate              # if project.yml or the file list changed
```

## Test seams (launch environment)

- `PDJ_USE_FIXTURE=1` — load `fixture-index.json` instead of CloudFront, and use
  an **isolated, auto-cleared** UserDefaults (settings + browse prefs reset each
  launch). Set by every UI test.
- `PDJ_START_SECTION=Settings` — land directly on a sidebar section.
- `PDJ_OPEN_FIRST_ALBUM=1` — deep-link into the first album (track table).

UI tests query controls via `app.el("id")` (XCUIHelpers) — a `.any` descendant
lookup so toolbar buttons + the segmented picker resolve identically on iOS and
macOS (they are `.buttons` on iOS but `.toolbars`/`.radioButtons` on macOS).

## iPhone / iPad (simulators — no signing)

```bash
# boot the targets once
xcrun simctl boot 'iPhone 17 Pro'  ; xcrun simctl boot 'iPad Pro 13-inch (M5)'

# full suite (unit + UI) on a device, signing off
xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO

# iPad: same, different destination + derivedDataPath (so runs don't share a build dir)
xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath build-ipad CODE_SIGNING_ALLOWED=NO
```

Run a single test: append `-only-testing:PocketDJTests` (unit) or
`-only-testing:PocketDJUITests/BrowseUITests/testSwitchToSongsListsTracks`.

**Never run two `xcodebuild` invocations against the same `-derivedDataPath`
concurrently** — the second clobbers `TEST_HOST` and fails. Give each its own dir.

## Targeted runs vs the full matrix

Running every UI class × iPhone + iPad + macOS on each change is wasteful (each UI
class is 20–100s/device; the whole unit bundle is ~0.3s). So, when verifying a change:

- **Always run the full unit bundle** — `-only-testing:PocketDJTests`. It's cheap; never narrow it.
- **Select UI classes from the change.** Map the changed paths
  (`git diff --name-only origin/main...HEAD`) to UI test classes via
  **`apple/docs/storybook-test-map.md` §B**, then pass one
  `-only-testing:PocketDJUITests/<Class>` per selected class.
- **Pick devices by what changed:** logic-only / most changes → **iPhone only**; a
  macOS-specific path (keyboard commands) → add **macOS**; an iPad layout → add **iPad**.
- **Escalate to run-all** (every class × all three devices) when the change hits a
  **shell/infra** row (`RootView`, `PocketDJApp`, `Theme`, `project.yml`,
  `XCUIHelpers`) or ≥3 feature rows. Run-all is otherwise reserved for **CI** and the
  **`/create-pr` judgment gate** — not every local iteration.

```bash
# e.g. a change under Performance/ + CollectionsStore → engine + collections, iPhone only
xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:PocketDJTests \
  -only-testing:PocketDJUITests/SetlistUITests    # + each UI class the matrix selected
```

See `apple/docs/storybook-test-map.md` for the chapter↔test index, the change→tests
matrix, and the macOS targeting note.

## macOS

Gatekeeper kills the unsigned XCUITest runner ("damaged"), so the runner **must be
signed** — but a plain `xcodebuild test` also hangs (`The test runner hung before
establishing connection`). Use the ad-hoc helper, which **ad-hoc signs** the app +
runner (build unsigned → `codesign --sign -` → `test-without-building`):

```bash
bash apple/scripts/test-macos.sh                 # full unit + UI suite on My Mac
# scope it (forwarded to test-without-building):
bash apple/scripts/test-macos.sh build-mactest \
  -only-testing:PocketDJUITests/BrowseUITests -only-testing:PocketDJTests
```

Ad-hoc (`codesign --sign -`) is the right signing here, not a fallback: it needs **no
provisioning profile and no device registration**. The "real cert" route
(`-allowProvisioningUpdates`) does **not** work headlessly on this Mac — even with the
Apple Development key CLI-accessible it fails with *"Device 'Levi's iMac' isn't
registered in your developer account"* / *"No profiles for 'com.levi.pocketdj' were
found"*. Fixing that means registering the iMac's UDID in the Developer portal and
minting a Mac App Development profile — a portal action that buys nothing over ad-hoc
for local testing. So: **sign ad-hoc; don't chase a provisioning profile.**

**First-run permission (one-time, not a signing issue):** the very first ad-hoc UI run
can fail with `Timed out while enabling automation mode` / `The test runner failed to
initialize for UI testing`. That's the macOS **Automation/Accessibility (TCC)**
permission for the test runner, *not* a signing problem — granting Automation to the
runner once (and quitting any stale `PocketDJ` instance the script's `killall` missed)
clears it permanently. Re-run; no signing change helps.

## Proof / debugging

- Simulator screenshots: `xcrun simctl io <UDID> screenshot out.png` (no Screen
  Recording permission needed — unlike `screencapture`).
- A green run prints `** TEST SUCCEEDED **` and `Executed N tests, with 0 failures`.

## Related

- **apple-build** skill — generating + building + signing.
- `apple/docs/build-and-test.md` — fuller reference incl. the signing saga.
